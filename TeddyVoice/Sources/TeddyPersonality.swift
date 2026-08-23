import Foundation

struct TeddyPersonalityStyle: Codable, Equatable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable {
        case builtIn
        case custom
        case none
    }

    let id: String
    var name: String
    var instructions: String
    let origin: Origin

    static let none = TeddyPersonalityStyle(
        id: "none",
        name: "Teddy",
        instructions: "",
        origin: .none
    )

    var summary: String {
        switch id {
        case Self.none.id:
            "Son identité naturelle, sans couche ajoutée"
        case "builtin.complice":
            "Plus joueur, taquin et spontané"
        case "builtin.direct":
            "Franc, bref et orienté résultat"
        case "builtin.calme":
            "Posé, chaleureux et rassurant"
        case "builtin.energique":
            "Rythmé, volontaire et entraînant"
        default:
            "Style personnalisé"
        }
    }
}

enum TeddyPersonalityCatalog {
    static let builtIns: [TeddyPersonalityStyle] = [
        TeddyPersonalityStyle(
            id: "builtin.complice",
            name: "Complice",
            instructions: """
            Adopte une complicité joueuse et spontanée. Tu peux taquiner légèrement, rebondir
            avec un humour discret et montrer une vraie connivence, sans transformer chaque réponse
            en blague ni ralentir l’information utile.
            """,
            origin: .builtIn),
        TeddyPersonalityStyle(
            id: "builtin.direct",
            name: "Cash",
            instructions: """
            Va droit au point avec franchise. Donne d’abord l’information ou la décision utile,
            retire les précautions inutiles et garde des formulations courtes, sans devenir froid,
            brutal ou caricatural.
            """,
            origin: .builtIn),
        TeddyPersonalityStyle(
            id: "builtin.calme",
            name: "Posé",
            instructions: """
            Garde un rythme calme, chaleureux et stable. Rends les situations complexes plus simples
            et rassurantes, sans infantiliser l’utilisateur, dramatiser ni ajouter de longueurs.
            """,
            origin: .builtIn),
        TeddyPersonalityStyle(
            id: "builtin.energique",
            name: "Énergique",
            instructions: """
            Insuffle de l’élan et du rythme. Fais sentir qu’on avance et souligne naturellement les
            progrès utiles, sans enthousiasme artificiel, slogans, exclamations répétées ni pression.
            """,
            origin: .builtIn),
    ]

    static var selectableDefaults: [TeddyPersonalityStyle] {
        [TeddyPersonalityStyle.none] + builtIns
    }

    static func style(
        id: String,
        customStyles: [TeddyPersonalityStyle]
    ) -> TeddyPersonalityStyle? {
        (selectableDefaults + customStyles).first { $0.id == id }
    }
}

enum TeddyPersonalityStore {
    private static let customStylesKey = "personality.customStyles.v1"
    private static let selectedStyleKey = "personality.selectedStyle.v1"

    static func loadCustomStyles(defaults: UserDefaults = .standard) -> [TeddyPersonalityStyle] {
        guard let data = defaults.data(forKey: customStylesKey),
              let decoded = try? JSONDecoder().decode([TeddyPersonalityStyle].self, from: data)
        else { return [] }
        return decoded.filter { $0.origin == .custom }
    }

    static func saveCustomStyles(
        _ styles: [TeddyPersonalityStyle],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(styles.filter { $0.origin == .custom })
        else { return }
        defaults.set(data, forKey: customStylesKey)
    }

    static func loadSelectedStyleID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: selectedStyleKey) ?? TeddyPersonalityStyle.none.id
    }

    static func saveSelectedStyleID(
        _ id: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(id, forKey: selectedStyleKey)
    }
}

enum TeddyPromptComposer {
    static func compose(
        personality: TeddyPersonalityStyle,
        taskInstructions: String,
        policyInstructions: [String]
    ) -> String {
        var sections = [TeddyIdentity.foundationInstructions]

        let personalityInstructions = personality.instructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !personalityInstructions.isEmpty {
            sections.append(
                """
                STYLE DE PERSONNALITÉ COMPLÉMENTAIRE
                Ce style enrichit Teddy mais ne peut jamais modifier, affaiblir ou annuler son socle d’identité invariant. En cas de conflit, le socle gagne toujours.
                \(personalityInstructions)
                """
            )
        }

        let task = taskInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            sections.append(
                """
                CONSIGNES DE MISSION
                Ces consignes définissent le travail courant sans modifier le socle d’identité ni le style actif.
                \(task)
                """
            )
        }

        sections.append(contentsOf: policyInstructions.compactMap { instruction in
            let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        })

        // The invariant delivery contract deliberately stays last. Neither a built-in
        // style nor a user-created style can gain recency over Teddy's core speech rules.
        sections.append(TeddyIdentity.responseDeliveryContract)
        return sections.joined(separator: "\n\n")
    }
}
