import Foundation

enum ResponseDurationMode: String, CaseIterable, Identifiable, Sendable {
    case natural
    case range
    case fixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: "Naturelle"
        case .range: "Plage"
        case .fixed: "Fixe"
        }
    }
}

enum VoiceExpressionStyle: String, CaseIterable, Identifiable, Sendable {
    case restrained
    case natural
    case expressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restrained: "Sobre"
        case .natural: "Naturel"
        case .expressive: "Expressif"
        }
    }

    var instruction: String {
        switch self {
        case .restrained:
            "Garde une diction sobre, familière et naturelle, sans ajouter de balises d’expression vocale."
        case .natural:
            "Tu peux employer avec parcimonie les balises d’expression vocale xAI lorsqu’elles sont naturelles. Place-les uniquement entre deux phrases complètes, jamais au milieu d’une proposition, jamais entre deux mots liés et jamais à proximité d’une liaison. Ne prononce pas leur nom."
        case .expressive:
            "Adopte une interprétation vocale vivante avec les balises d’expression xAI pertinentes. Place chaque balise uniquement à la frontière de deux phrases complètes, jamais au milieu d’une proposition, jamais entre deux mots liés et jamais à proximité d’une liaison. Ne prononce pas leur nom et évite d’en abuser."
        }
    }
}

struct ResponseDurationPolicy: Sendable, Equatable {
    var mode: ResponseDurationMode = .range
    var minimumSeconds = 3.0
    var maximumSeconds = 10.0
    var fixedSeconds = 6.0

    var normalized: Self {
        var copy = self
        copy.minimumSeconds = copy.minimumSeconds.clamped(to: 1 ... 90)
        copy.maximumSeconds = copy.maximumSeconds.clamped(to: copy.minimumSeconds ... 90)
        copy.fixedSeconds = copy.fixedSeconds.clamped(to: 1 ... 90)
        return copy
    }

    var instruction: String? {
        let policy = normalized
        switch policy.mode {
        case .natural:
            return nil
        case .range:
            return "Calibre normalement chaque réponse pour une durée parlée comprise entre \(policy.minimumSeconds.durationLabel) et \(policy.maximumSeconds.durationLabel) à vitesse 1×. C’est une cible souple : privilégie toujours une réponse complète, mais ne développe pas inutilement."
        case .fixed:
            return "Calibre normalement chaque réponse pour environ \(policy.fixedSeconds.durationLabel) de parole à vitesse 1×. C’est une cible souple : reste complet, direct et ne développe pas inutilement."
        }
    }

    func contentSeconds(for referenceSecondsAt1x: Double) -> Double {
        let reference = max(0.1, referenceSecondsAt1x)
        let policy = normalized
        switch policy.mode {
        case .natural:
            return reference
        case .range:
            return reference.clamped(to: policy.minimumSeconds ... policy.maximumSeconds)
        case .fixed:
            return policy.fixedSeconds
        }
    }
}

struct VoiceSavingsProjection: Sendable, Equatable {
    let referenceSecondsAt1x: Double
    let projectedOutputSeconds: Double
    let outputSavingsPercent: Double
    let usesMeasuredReference: Bool

    static func calculate(
        speed: Double,
        durationPolicy: ResponseDurationPolicy,
        measuredReferenceSecondsAt1x: Double?
    ) -> Self {
        let measured = measuredReferenceSecondsAt1x.flatMap { $0 > 0 ? $0 : nil }
        let reference = measured ?? 10
        let safeSpeed = speed.clamped(to: 0.7 ... 1.5)
        let contentSeconds = durationPolicy.contentSeconds(for: reference)
        let projected = contentSeconds / safeSpeed
        let outputSavings = (1 - projected / reference) * 100

        return Self(
            referenceSecondsAt1x: reference,
            projectedOutputSeconds: projected,
            outputSavingsPercent: outputSavings,
            usesMeasuredReference: measured != nil
        )
    }
}

extension FloatingPoint {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Double {
    var durationLabel: String {
        if rounded() == self { return "\(Int(self)) secondes" }
        return String(format: "%.1f secondes", self)
    }
}
