import Foundation

enum SpokenFrenchPronunciation {
    static let replacements: [String: String] = {
        var values: [String: String] = [:]

        func add(_ written: String, _ spoken: String) {
            values[written] = spoken
        }

        func addFamily(_ writtenStem: String, _ spokenStem: String, suffixes: [String]) {
            for suffix in suffixes {
                add(writtenStem + suffix, spokenStem + suffix)
            }
        }

        // High-frequency grammatical fusions. The longest phrase is applied first.
        add("il n'y a pas", "y a pas")
        add("il n’y a pas", "y a pas")
        add("il y a", "y a")
        add("que je", "qu'j'")
        add("que j’", "qu'j'")
        add("que tu", "qu'tu")
        add("que nous", "qu'nous")
        add("ce que", "c'que")
        add("ce qui", "c'qui")
        add("de la", "d'la")
        add("de ce", "d'ce")
        add("de cette", "d'cette")
        add("tout le monde", "tout l'monde")

        // Productive families whose initial or internal schwa is routinely dropped.
        addFamily(
            "demand",
            "d'mand",
            suffixes: [
                "e", "es", "ent", "er", "é", "ée", "és", "ées", "ais", "ait",
                "ions", "iez", "aient", "era", "eras", "erons", "erez", "eront",
                "erais", "erait", "erions", "eriez", "eraient",
            ]
        )
        addFamily(
            "regard",
            "r'gard",
            suffixes: [
                "e", "es", "ent", "er", "é", "ée", "és", "ées", "ais", "ait",
                "ions", "iez", "aient", "era", "eras", "erons", "erez", "eront",
            ]
        )
        addFamily(
            "recommenc",
            "r'commenc",
            suffixes: ["e", "es", "ent", "er", "é", "ée", "és", "ées", "ais", "ait", "era", "erait"]
        )
        addFamily(
            "retourn",
            "r'tourn",
            suffixes: ["e", "es", "ent", "er", "é", "ée", "és", "ées", "ais", "ait", "era", "erait"]
        )

        add("petit déjeuner", "p'tit déj")
        add("petits déjeuners", "p'tits déj")
        add("petit", "p'tit")
        add("petite", "p'tite")
        add("petits", "p'tits")
        add("petites", "p'tites")
        add("peut-être", "p't-être")
        add("maintenant", "maint'nant")
        add("demain", "d'main")
        add("debout", "d'bout")
        add("dedans", "d'dans")
        add("dehors", "d'hors")
        add("devant", "d'vant")
        add("semaine", "s'maine")
        add("semaines", "s'maines")
        add("chemin", "ch'min")
        add("chemins", "ch'mins")
        add("cheval", "ch'val")
        add("chevaux", "ch'vaux")
        add("cheveu", "ch'veu")
        add("cheveux", "ch'veux")
        add("fenêtre", "f'nêtre")
        add("fenêtres", "f'nêtres")
        add("genou", "g'nou")
        add("genoux", "g'noux")
        add("secret", "s'cret")
        add("secrets", "s'crets")
        add("secrète", "s'crète")
        add("secrètes", "s'crètes")
        add("second", "s'cond")
        add("seconde", "s'conde")
        add("seconds", "s'conds")
        add("secondes", "s'condes")

        add("venir", "v'nir")
        add("venu", "v'nu")
        add("venue", "v'nue")
        add("venus", "v'nus")
        add("venues", "v'nues")
        add("venait", "v'nait")
        add("venaient", "v'naient")
        add("venez", "v'nez")
        add("venons", "v'nons")
        add("revenir", "r'venir")
        add("revenu", "r'venu")
        add("revenue", "r'venue")
        add("devenir", "d'venir")
        add("devenu", "d'venu")
        add("devenue", "d'venue")
        add("tenir", "t'nir")
        add("tenait", "t'nait")
        add("tenaient", "t'naient")

        add("appartement", "appart'ment")
        add("appartements", "appart'ments")
        add("gouvernement", "gouvern'ment")
        add("gouvernements", "gouvern'ments")
        add("mouvement", "mouv'ment")
        add("mouvements", "mouv'ments")
        add("seulement", "seul'ment")
        add("tellement", "tell'ment")
        add("justement", "just'ment")
        add("simplement", "simpl'ment")
        add("rapidement", "rapid'ment")
        add("exactement", "exact'ment")
        add("probablement", "probabl'ment")

        return values
    }()

    /// The streaming TTS API accepts replacement keys made only of letters,
    /// digits, ASCII apostrophes and spaces. Keep the richer local transcript
    /// rules, but never let punctuation such as a hyphen invalidate the whole
    /// TTS session update.
    static let ttsReplacements: [String: String] = {
        replacements.reduce(into: [:]) { result, replacement in
            let key = replacement.key.replacingOccurrences(of: "’", with: "'")
            let isValid = key.unicodeScalars.allSatisfy { scalar in
                CharacterSet.letters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar)
                    || scalar.value == 0x20
                    || scalar.value == 0x27
            }
            if isValid { result[key] = replacement.value }
        }
    }()

    private static let transcriptExpression: NSRegularExpression? = {
        let alternatives = replacements.keys
            .sorted {
                if $0.count == $1.count { return $0 < $1 }
                return $0.count > $1.count
            }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        guard !alternatives.isEmpty else { return nil }
        return try? NSRegularExpression(
            pattern: "(?i)(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])"
        )
    }()

    static func renderedTranscript(_ text: String) -> String {
        guard let transcriptExpression else { return text }
        var result = text
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = transcriptExpression.matches(in: text, range: fullRange)

        for match in matches.reversed() {
            guard let sourceRange = Range(match.range, in: result) else { continue }
            let written = String(result[sourceRange]).lowercased()
            guard let spoken = replacements[written] else { continue }
            result.replaceSubrange(sourceRange, with: spoken)
        }

        return result
    }
}
