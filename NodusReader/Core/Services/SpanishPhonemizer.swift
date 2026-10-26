// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Spanish (Spain) text to the phonemes Kokoro's Spanish voices were trained on.
///
/// Kokoro's upstream pipeline phonemizes Spanish with espeak-ng (`es`) and then
/// maps a few tied pairs to single symbols (misaki's `EspeakG2P`: `a^ɪ` → `I`,
/// `e^ɪ` → `A`, `a^ʊ` → `W`, `t^ʃ` → `ʧ`). espeak-ng is GPL and is not shipped
/// here; Spanish spelling is regular enough that its rules can be reproduced
/// directly: stress from accents and word endings, secondary stress every
/// second syllable before it, unstressed function words, diphthongs and
/// glides, b/d/g lenition after vowels (also across words, reset at pauses),
/// nasal assimilation, tap and trill r, θ for c/z and x for j.
enum SpanishG2P {
    /// Phonemes for `text`, with punctuation kept where Kokoro has a token for it.
    static func phonemize(_ text: String) -> String {
        let tokens = tokenize(SpanishTextNormalizer.normalize(text))
        var output = ""
        var clause: [String] = []

        func flushClause() {
            guard !clause.isEmpty else { return }
            let rendered = renderClause(clause)
            if !output.isEmpty, !output.hasSuffix(" "), !output.hasSuffix("(") && !output.hasSuffix("“") {
                output += " "
            }
            output += rendered
            clause.removeAll()
        }

        for token in tokens {
            switch token {
            case .word(let word):
                clause.append(word)
            case .pause(let mark):
                flushClause()
                if let mark {
                    if mark == "(" || mark == "“" {
                        if !output.isEmpty, !output.hasSuffix(" ") { output += " " }
                        output += mark
                    } else {
                        output += mark
                    }
                }
            }
        }
        flushClause()
        return output.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Tokens

    enum Token: Equatable {
        case word(String)
        /// A clause boundary, with the punctuation Kokoro can read (if any).
        case pause(String?)
    }

    private static let pauseMarks: [Character: String?] = [
        ",": ",", ".": ".", ";": ";", ":": ":", "!": "!", "?": "?", "…": "…",
        "—": "—", "–": "—", "(": "(", ")": ")", "\"": "\"", "“": "“", "”": "”",
        "«": "“", "»": "”", "¿": nil, "¡": nil, "[": "(", "]": ")"
    ]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        func flushWord() {
            if !word.isEmpty { tokens.append(.word(word)) }
            word = ""
        }
        for character in text {
            if character.isLetter {
                word.append(character)
            } else if character == "'" || character == "’", !word.isEmpty {
                continue
            } else if let mark = pauseMarks[character] {
                flushWord()
                tokens.append(.pause(mark))
            } else {
                // Spaces, hyphens inside compounds and anything unreadable.
                flushWord()
            }
        }
        flushWord()
        return tokens
    }

    // MARK: Words

    /// A sound before its context is known: b/d/g and n depend on the sound
    /// before or after them, possibly in another word.
    enum Phone: Equatable {
        case consonant(String)
        case b, d, g
        case n
        case vowel(Vowel)
    }

    struct Vowel: Equatable {
        var base: Character
        var accented: Bool
        /// Hiatus forced by spelling (ü, or an h between the vowels).
        var hiatus = false
        /// Said as a vowel rather than a glide, without moving the stress
        /// (patria, ruido, luego, llueve).
        var plain = false
        /// The vowel spelled `y` at the end of a word (rey, muy).
        var fromY = false

        var isStrong: Bool { accented || !(base == "i" || base == "u") }
    }

    enum Stress { case none, secondary, primary }

    /// One transcribed word: phones, the syllable nuclei (indices into
    /// `phones`) and the stress of each nucleus.
    struct Word {
        var phones: [Phone]
        var nuclei: [[Int]]
        var stress: [Stress]
        /// `-mente` adverbs keep the stem's stress and add their own.
        var suffix: [Phone] = []
        var suffixNuclei: [[Int]] = []
    }

    private static let unstressed: Set<String> = [
        "el", "la", "lo", "los", "las", "le", "les", "se", "me", "te", "nos", "os",
        "mi", "mis", "tu", "tus", "su", "sus", "de", "del", "a", "al", "en", "con",
        "por", "sin", "que", "y", "e", "o", "u", "si", "quien", "quienes", "tras"
    ]

    private static let secondaryOnly: Set<String> = [
        "para", "pero", "como", "cuando", "donde", "desde", "porque", "sobre", "entre",
        "hacia", "hasta", "mientras", "aunque", "adonde", "ante", "cuanto", "cuanta",
        "cuantos", "cuantas", "nuestro", "nuestra", "nuestros", "nuestras", "vuestro", "vuestra",
        "vuestros", "vuestras"
    ]

    /// Words whose x is the old spelling of j.
    private static let xAsJota: Set<String> = [
        "méxico", "mexicano", "mexicana", "mexicanos", "mexicanas", "texas", "oaxaca", "xavier"
    ]

    static func transcribe(_ raw: String) -> Word {
        let word = raw.lowercased()
        if word.hasSuffix("mente"), word.count > 5 {
            let stem = String(word.dropLast(5))
            if stem.count >= 4 || stem.contains(where: { "áéíóú".contains($0) }) {
                let head = transcribe(stem)
                let tail = transcribe("mente")
                return Word(phones: head.phones, nuclei: head.nuclei, stress: head.stress,
                            suffix: tail.phones, suffixNuclei: tail.nuclei)
            }
        }
        let phones = graphemesToPhones(word)
        // The primary stress counts a vowel said in hiatus after r or l as
        // part of its diphthong (pa-tria); syllables, and the secondary stress
        // every second syllable before the primary, count it on its own.
        let spelled = syllableNuclei(phones)
        let nuclei = spelled.flatMap { splitPlainVowels($0, phones: phones) }
        var stress = [Stress](repeating: .none, count: nuclei.count)
        if let spelledPrimary = primaryStress(word: word, phones: phones, nuclei: spelled) {
            let peak = spelled[spelledPrimary][peakPosition(spelled[spelledPrimary], phones: phones)]
            let primary = nuclei.firstIndex { $0.contains(peak) } ?? 0
            stress[primary] = .primary
            var index = 0
            while index <= primary - 2 {
                stress[index] = .secondary
                index += 2
            }
        }
        return Word(phones: phones, nuclei: nuclei, stress: stress)
    }

    private static func vowel(at index: Int, in phones: [Phone]) -> Vowel? {
        if case .vowel(let vowel) = phones[index] { return vowel }
        return nil
    }

    /// The syllabic vowel of a nucleus: the strong one, or the last of two
    /// weak vowels (except a final y: muy).
    static func peakPosition(_ nucleus: [Int], phones: [Phone]) -> Int {
        let vowels = nucleus.compactMap { vowel(at: $0, in: phones) }
        return vowels.firstIndex { $0.isStrong } ?? (vowels.last?.fromY == true ? 0 : vowels.count - 1)
    }

    private static func splitPlainVowels(_ nucleus: [Int], phones: [Phone]) -> [[Int]] {
        var parts: [[Int]] = []
        var current: [Int] = []
        for index in nucleus {
            if vowel(at: index, in: phones)?.plain == true {
                if !current.isEmpty { parts.append(current) }
                parts.append([index])
                current = []
            } else {
                current.append(index)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func graphemesToPhones(_ word: String) -> [Phone] {
        let letters = Array(word.map(foldForeign))
        var phones: [Phone] = []
        var index = 0
        func letter(_ offset: Int) -> Character? {
            let position = index + offset
            return letters.indices.contains(position) ? letters[position] : nil
        }
        func isFrontVowel(_ character: Character?) -> Bool {
            guard let character else { return false }
            return "eiéí".contains(character)
        }
        func isVowelLetter(_ character: Character?) -> Bool {
            guard let character else { return false }
            return "aeiouáéíóúü".contains(character)
        }
        var afterSilentH = false
        while index < letters.count {
            let current = letters[index]
            let next = letter(1)
            let followsSilentH = afterSilentH
            afterSilentH = false
            switch current {
            case "a", "e", "i", "o", "u":
                var vowel = Vowel(base: current, accented: false)
                if (current == "i" || current == "u"), isVowelLetter(next) {
                    vowel.plain = keepsOwnSyllable(after: phones)
                }
                vowel.hiatus = followsSilentH
                phones.append(.vowel(vowel))
            case "á", "é", "í", "ó", "ú":
                phones.append(.vowel(Vowel(base: unaccented(current), accented: true, hiatus: followsSilentH)))
            case "ü":
                phones.append(.vowel(Vowel(base: "u", accented: false, hiatus: true)))
            case "b", "v":
                phones.append(.b)
            case "c":
                if next == "h" {
                    phones.append(.consonant("ʧ"))
                    index += 1
                } else if isFrontVowel(next) {
                    phones.append(.consonant("θ"))
                } else {
                    phones.append(.consonant("k"))
                }
            case "d":
                phones.append(.d)
            case "f":
                phones.append(.consonant("f"))
            case "g":
                if next == "u", isFrontVowel(letter(2)) {
                    phones.append(.g)
                    index += 1
                } else if isFrontVowel(next) {
                    phones.append(.consonant("x"))
                } else {
                    phones.append(.g)
                }
            case "h":
                if case .vowel? = phones.last { afterSilentH = true }
                index += 1
                continue
            case "j":
                phones.append(.consonant("x"))
            case "k":
                phones.append(.consonant("k"))
            case "l":
                if next == "l" {
                    phones.append(.consonant("ʎ"))
                    index += 1
                } else {
                    phones.append(.consonant("l"))
                }
            case "m":
                phones.append(.consonant("m"))
            case "n":
                phones.append(.n)
            case "ñ":
                phones.append(.consonant("ɲ"))
            case "p":
                phones.append(.consonant("p"))
            case "q":
                phones.append(.consonant("k"))
                if next == "u" { index += 1 }
            case "r":
                if word == "ser", index == 2 {
                    phones.append(.consonant("r"))
                } else if next == "r" {
                    phones.append(.consonant("r"))
                    index += 1
                } else if index == 0 {
                    phones.append(.consonant("r"))
                } else if let previous = phones.last,
                          previous == .n || previous == .consonant("l") || previous == .consonant("s") {
                    phones.append(.consonant("r"))
                } else {
                    phones.append(.consonant("ɾ"))
                }
            case "s":
                phones.append(.consonant("s"))
            case "t":
                phones.append(.consonant("t"))
            case "w":
                phones.append(.consonant("w"))
            case "x":
                if xAsJota.contains(word) {
                    phones.append(.consonant("x"))
                } else if index == 0 {
                    phones.append(.consonant("s"))
                } else {
                    phones.append(.consonant("k"))
                    phones.append(.consonant("s"))
                }
            case "y":
                if isVowelLetter(next) {
                    phones.append(.consonant("ʝ"))
                } else {
                    phones.append(.vowel(Vowel(base: "i", accented: false, fromY: true)))
                }
            case "z":
                phones.append(.consonant("θ"))
            default:
                break
            }
            index += 1
        }
        return phones
    }

    /// espeak says i and u as full vowels after a trill r (ruido), after r or
    /// l closing a consonant cluster (patria, prueba, biblioteca), after a
    /// word-initial l (luego, Luis) and after ll (llueve).
    private static func keepsOwnSyllable(after phones: [Phone]) -> Bool {
        guard let previous = phones.last else { return false }
        switch previous {
        case .consonant("r"), .consonant("ʎ"):
            return true
        case .consonant("ɾ"), .consonant("l"):
            guard phones.count >= 2 else { return previous == .consonant("l") }
            if case .vowel = phones[phones.count - 2] { return false }
            return true
        default:
            return false
        }
    }

    private static func foldForeign(_ character: Character) -> Character {
        switch character {
        case "à", "â", "ä", "ã": "a"
        case "è", "ê", "ë": "e"
        case "ì", "î", "ï": "i"
        case "ò", "ô", "ö", "õ": "o"
        case "ù", "û": "u"
        case "ç": "s"
        default: character
        }
    }

    private static func unaccented(_ character: Character) -> Character {
        switch character {
        case "á": "a"
        case "é": "e"
        case "í": "i"
        case "ó": "o"
        default: "u"
        }
    }

    /// Groups adjacent vowels into syllable nuclei: a weak vowel (i, u without
    /// an accent) shares a syllable with its neighbour; two strong vowels are
    /// in hiatus; two weak vowels share one (cui-da-do, ciu-dad).
    static func syllableNuclei(_ phones: [Phone]) -> [[Int]] {
        var nuclei: [[Int]] = []
        var previousWasVowel = false
        for (index, phone) in phones.enumerated() {
            guard case .vowel(let vowel) = phone else {
                previousWasVowel = false
                continue
            }
            if previousWasVowel, var current = nuclei.last, let lastIndex = current.last,
               case .vowel(let previous) = phones[lastIndex] {
                let hasStrong = current.contains { position in
                    if case .vowel(let member) = phones[position] { return member.isStrong }
                    return false
                }
                let bothWeak = !previous.isStrong && !vowel.isStrong
                let joins: Bool
                if vowel.hiatus || previous.hiatus {
                    joins = false
                } else if bothWeak {
                    joins = true
                } else if vowel.isStrong {
                    joins = !hasStrong
                } else {
                    joins = true
                }
                if joins {
                    current.append(index)
                    nuclei[nuclei.count - 1] = current
                    previousWasVowel = true
                    continue
                }
            }
            nuclei.append([index])
            previousWasVowel = true
        }
        return nuclei
    }

    private static func primaryStress(word: String, phones: [Phone], nuclei: [[Int]]) -> Int? {
        guard !nuclei.isEmpty else { return nil }
        for (position, nucleus) in nuclei.enumerated() {
            for index in nucleus {
                if case .vowel(let vowel) = phones[index], vowel.accented { return position }
            }
        }
        guard nuclei.count > 1 else { return 0 }
        let last = word.last.map(foldForeign)
        let endsOpen = last.map { "aeioun s".contains($0) && $0 != " " } ?? true
        return endsOpen ? nuclei.count - 2 : nuclei.count - 1
    }

    // MARK: Clauses

    private struct Placed {
        var word: Word
        var text: String
        var stressScale: Stress
    }

    /// Renders the words of one clause: function words lose their stress,
    /// then b/d/g and n are resolved against the neighbouring sounds.
    static func renderClause(_ words: [String]) -> String {
        var placed = words.map { text -> Placed in
            let lower = text.lowercased()
            let scale: Stress
            if words.count == 1 {
                scale = .primary
            } else if unstressed.contains(lower) {
                scale = .none
            } else if secondaryOnly.contains(lower) {
                scale = .secondary
            } else {
                scale = .primary
            }
            return Placed(word: transcribe(text), text: lower, stressScale: scale)
        }
        for index in placed.indices {
            let scale = placed[index].stressScale
            guard scale != .primary else { continue }
            placed[index].word.stress = placed[index].word.stress.map { stress in
                stress == .primary ? scale : .none
            }
        }

        // Every phone of the clause in order, to look across word boundaries.
        var flat: [Phone] = []
        var ranges: [(word: Int, part: Int, range: Range<Int>)] = []
        for (index, item) in placed.enumerated() {
            let start = flat.count
            flat.append(contentsOf: item.word.phones)
            ranges.append((index, 0, start..<flat.count))
            if !item.word.suffix.isEmpty {
                let suffixStart = flat.count
                flat.append(contentsOf: item.word.suffix)
                ranges.append((index, 1, suffixStart..<flat.count))
            }
        }
        let wordEnds = Set(ranges.filter { $0.part == 0 && placed[$0.word].word.suffix.isEmpty || $0.part == 1 }
            .map { $0.range.upperBound - 1 })
        let resolved = flat.indices.map { resolve(flat, at: $0, isWordEnd: wordEnds.contains($0)) }

        var rendered: [String] = []
        for (index, item) in placed.enumerated() {
            var text = ""
            for entry in ranges where entry.word == index {
                let nuclei = entry.part == 0 ? item.word.nuclei : item.word.suffixNuclei
                let stress = entry.part == 0
                    ? item.word.stress
                    : [Stress](repeating: .none, count: nuclei.count).enumerated().map { position, _ in
                        position == 0 ? .primary : .none
                    }
                text += renderWord(phones: Array(flat[entry.range]),
                                   symbols: Array(resolved[entry.range]),
                                   nuclei: nuclei, stress: stress, opensE: entry.part == 0)
            }
            rendered.append(text)
        }
        return rendered.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func resolve(_ phones: [Phone], at index: Int, isWordEnd: Bool) -> String {
        func isConsonant(_ phone: Phone?) -> Bool {
            guard let phone else { return false }
            if case .vowel = phone { return false }
            return true
        }
        let previous = index > 0 ? phones[index - 1] : nil
        let next = index + 1 < phones.count ? phones[index + 1] : nil
        let afterNasal = previous == .n || previous == .consonant("m")
        switch phones[index] {
        case .consonant(let symbol):
            if symbol == "ʝ", previous == .n || previous == .consonant("l") { return "ʤ" }
            return symbol
        case .vowel:
            return ""
        case .b:
            return previous == nil || afterNasal ? "b" : "β"
        case .g:
            if isConsonant(next), next != .consonant("ɾ"), next != .consonant("l"), next != .consonant("r") {
                return "ɡ"
            }
            return previous == nil || afterNasal ? "ɡ" : "ɣ"
        case .d:
            // A d closing a syllable (admirar) or the clause stays a stop.
            if next == nil || (isConsonant(next) && next != .consonant("ɾ")) {
                return "d"
            }
            return previous == nil || afterNasal ? "d" : "ð"
        case .n:
            switch next {
            case .b?, .consonant("p")?: return "m"
            case .consonant("f")? where isWordEnd: return "m"
            case .g?, .consonant("x")?: return "ŋ"
            default: return "n"
            }
        }
    }

    private static func renderWord(phones: [Phone], symbols: [String], nuclei: [[Int]],
                                   stress: [Stress], opensE: Bool) -> String {
        var nucleusOf: [Int: Int] = [:]
        for (position, nucleus) in nuclei.enumerated() {
            for index in nucleus { nucleusOf[index] = position }
        }
        var output = ""
        var index = 0
        while index < phones.count {
            guard let position = nucleusOf[index] else {
                output += symbols[index]
                index += 1
                continue
            }
            let nucleus = nuclei[position]
            output += renderNucleus(nucleus.map { phones[$0] }, stress: stress[position],
                                    followedByNasalCoda: opensE && nasalCoda(after: nucleus.last!, in: phones))
            index = nucleus.last! + 1
        }
        return output
    }

    /// espeak opens a stressed e before n plus another consonant (fuente, tengo).
    private static func nasalCoda(after index: Int, in phones: [Phone]) -> Bool {
        guard index + 2 < phones.count, phones[index + 1] == .n else { return false }
        if case .vowel = phones[index + 2] { return false }
        return true
    }

    private static func renderNucleus(_ members: [Phone], stress: Stress, followedByNasalCoda: Bool) -> String {
        let vowels = members.compactMap { phone -> Vowel? in
            if case .vowel(let vowel) = phone { return vowel }
            return nil
        }
        guard !vowels.isEmpty else { return "" }
        let peak = vowels.firstIndex { $0.isStrong }
            ?? (vowels.last?.fromY == true ? 0 : vowels.count - 1)
        var output = ""
        for vowel in vowels[..<peak] {
            output += vowel.plain ? String(vowel.base) : (vowel.base == "i" ? "j" : "w")
        }
        let mark: String = switch stress {
        case .primary: "ˈ"
        case .secondary: "ˌ"
        case .none: ""
        }
        var core = String(vowels[peak].base)
        var offglides = Array(vowels[(peak + 1)...])
        if core == "e", stress == .primary, followedByNasalCoda, offglides.isEmpty, !vowels[peak].accented {
            core = "ɛ"
        }
        if let glide = offglides.first, !vowels[peak].accented {
            switch (core, glide.base) {
            case ("a", "i"): core = "I"; offglides.removeFirst()
            case ("e", "i"): core = "A"; offglides.removeFirst()
            case ("a", "u"): core = "W"; offglides.removeFirst()
            case ("o", "i"): core = "oɪ"; offglides.removeFirst()
            case ("e", "u"): core = "eʊ"; offglides.removeFirst()
            case ("o", "u"): core = "O"; offglides.removeFirst()
            default: break
            }
        }
        output += mark + core
        for glide in offglides {
            // After a written accent espeak keeps the vowel (habéis: -ˈeis).
            output += vowels[peak].accented || glide.plain ? String(glide.base) : (glide.base == "i" ? "j" : "w")
        }
        return output
    }
}

/// Numbers, abbreviations and symbols spelled out in Spanish before
/// phonemization, so that "1605" and "Sr." are read as words.
enum SpanishTextNormalizer {
    static func normalize(_ text: String) -> String {
        var result = text
        for (abbreviation, expansion) in abbreviations {
            result = result.replacingOccurrences(of: abbreviation, with: expansion)
        }
        for (symbol, word) in symbols {
            result = result.replacingOccurrences(of: symbol, with: word)
        }
        result = romanNumerals(in: result)
        result = spellNumbers(in: result)
        return result
    }

    private static let abbreviations: [(String, String)] = [
        ("EE. UU.", "Estados Unidos"), ("EE.UU.", "Estados Unidos"),
        ("Srta.", "señorita"), ("Sra.", "señora"), ("Sr.", "señor"),
        ("Dra.", "doctora"), ("Dr.", "doctor"), ("Dña.", "doña"),
        ("Uds.", "ustedes"), ("Ud.", "usted"), ("Vd.", "usted"),
        ("etc.", "etcétera"), ("págs.", "páginas"), ("pág.", "página"),
        ("núm.", "número"), ("aprox.", "aproximadamente")
    ]

    private static let symbols: [(String, String)] = [
        ("%", " por ciento"), ("€", " euros"), ("&", " y "), ("+", " más "),
        ("=", " igual a "), ("°", " grados")
    ]

    private static let spellOut: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.numberStyle = .spellOut
        return formatter
    }()

    private static let ordinals = [
        1: "primero", 2: "segundo", 3: "tercero", 4: "cuarto", 5: "quinto",
        6: "sexto", 7: "séptimo", 8: "octavo", 9: "noveno", 10: "décimo"
    ]

    static func spellNumbers(in text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d{3})+|\d+)(?:([.,])(\d+))?([ºª])?"#)
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let integerText = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ".", with: "")
            let separator = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : nil
            let fraction = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : nil
            let ordinalMark = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : nil
            var words: String
            if let value = Int(integerText) {
                if let ordinalMark, let ordinal = ordinals[value] {
                    words = ordinalMark == "ª" ? String(ordinal.dropLast()) + "a" : ordinal
                } else {
                    words = spellOut.string(from: NSNumber(value: value)) ?? integerText
                }
            } else {
                words = integerText
            }
            if let separator, let fraction {
                if separator == "." && fraction.count == 3 {
                    // "1.000" was matched as an integer above; this is "12.345" style.
                    let joined = Int(integerText + fraction).flatMap { spellOut.string(from: NSNumber(value: $0)) }
                    words = joined ?? words
                } else if let fractionValue = Int(fraction) {
                    let leadingZeros = fraction.prefix { $0 == "0" }.map { _ in "cero" }
                    let spelled = spellOut.string(from: NSNumber(value: fractionValue)) ?? fraction
                    words += " coma " + (leadingZeros + [spelled]).joined(separator: " ")
                }
            }
            output += " \(words) "
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    private static let romanKeywords: Set<String> = [
        "capítulo", "capitulo", "libro", "parte", "tomo", "siglo", "acto", "escena", "canto",
        "volumen", "título", "titulo", "artículo", "articulo", "lección", "leccion"
    ]

    /// "Capítulo IV" and a heading made of a numeral alone are read as numbers.
    static func romanNumerals(in text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let alone = words.filter { !$0.isEmpty }.count == 1
        var output: [String] = []
        for word in words {
            let core = word.trimmingCharacters(in: .punctuationCharacters)
            let previous = output.last { !$0.isEmpty }?.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            if !core.isEmpty, alone || previous.map(romanKeywords.contains) == true,
               let value = romanValue(core) {
                output.append(word.replacingOccurrences(of: core, with: String(value)))
            } else {
                output.append(word)
            }
        }
        return output.joined(separator: " ")
    }

    static func romanValue(_ text: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        guard !text.isEmpty, text.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        let digits = text.compactMap { values[$0] }
        for (index, value) in digits.enumerated() {
            if index + 1 < digits.count, value < digits[index + 1] { total -= value } else { total += value }
        }
        guard total > 0, total < 4000, roman(total) == text else { return nil }
        return total
    }

    private static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"),
                                      (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"),
                                      (5, "V"), (4, "IV"), (1, "I")]
        var remaining = number
        var output = ""
        for (value, symbol) in table {
            while remaining >= value {
                output += symbol
                remaining -= value
            }
        }
        return output
    }
}
