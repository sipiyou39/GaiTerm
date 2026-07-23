#if os(macOS)
import Foundation

/// Authenticated, versioned event received through GaiTerm's private URL scheme.
///
/// The authentication token intentionally remains outside `GaiCompanionEvent`:
/// it belongs to the transport boundary and must be validated by the manager
/// before the provider-independent event reaches the activity reducer.
struct GaiCompanionEventEnvelope: Equatable, Sendable {
    #if DEBUG
    static let scheme = "gaiterm-debug"
    #else
    static let scheme = "gaiterm"
    #endif
    static let host = "agent-event"
    static let currentVersion = 1

    let version: Int
    let token: String
    let event: GaiCompanionEvent

    init(url: URL, receivedAt: Date = Date()) throws {
        guard url.absoluteString.utf8.count <= Self.maximumURLByteCount else {
            throw GaiCompanionEventTransportError.requestTooLarge
        }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw GaiCompanionEventTransportError.invalidRoute
        }
        guard components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw GaiCompanionEventTransportError.invalidRoute
        }

        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard Self.allowedFieldNames.contains(item.name) else {
                throw GaiCompanionEventTransportError.unknownField(item.name)
            }
            guard fields[item.name] == nil else {
                throw GaiCompanionEventTransportError.duplicateField(item.name)
            }
            guard let value = item.value else {
                throw GaiCompanionEventTransportError.invalidField(item.name)
            }
            fields[item.name] = value
        }

        let rawVersion = try Self.requiredField("v", in: fields)
        guard rawVersion == String(Self.currentVersion) else {
            throw GaiCompanionEventTransportError.unsupportedVersion(rawVersion)
        }

        let rawSurfaceID = try Self.requiredField("surface", in: fields)
        guard rawSurfaceID.utf8.count == 36,
              let surfaceID = UUID(uuidString: rawSurfaceID) else {
            throw GaiCompanionEventTransportError.invalidField("surface")
        }

        let token = try Self.validatedIdentifier(
            try Self.requiredField("token", in: fields),
            field: "token",
            minimumBytes: 16,
            maximumBytes: 512)

        let rawProvider = try Self.requiredField("provider", in: fields)
        guard Self.isProviderIdentifier(rawProvider) else {
            throw GaiCompanionEventTransportError.invalidField("provider")
        }

        let rawKind = try Self.requiredField("kind", in: fields)
        guard let kind = GaiCompanionEventKind(rawValue: rawKind) else {
            throw GaiCompanionEventTransportError.invalidField("kind")
        }

        let eventID = try Self.validatedIdentifier(
            try Self.requiredField("event", in: fields),
            field: "event",
            minimumBytes: 1,
            maximumBytes: 256)

        let turnID = try fields["turn"].map {
            try Self.validatedIdentifier(
                $0,
                field: "turn",
                minimumBytes: 1,
                maximumBytes: 256)
        }
        let message = try fields["message"].map {
            try Self.validatedMessage($0, field: "message")
        }

        self.version = Self.currentVersion
        self.token = token
        self.event = GaiCompanionEvent(
            surfaceID: surfaceID,
            provider: GaiCompanionProvider(rawValue: rawProvider),
            eventID: eventID,
            turnID: turnID,
            kind: kind,
            timestamp: receivedAt,
            message: message)
    }

    private static let maximumURLByteCount = 8_192
    private static let allowedFieldNames: Set<String> = [
        "v", "surface", "token", "provider", "kind", "event", "turn", "message",
    ]

    private static func requiredField(
        _ name: String,
        in fields: [String: String]
    ) throws -> String {
        guard let value = fields[name] else {
            throw GaiCompanionEventTransportError.missingField(name)
        }
        guard !value.isEmpty else {
            throw GaiCompanionEventTransportError.invalidField(name)
        }
        return value
    }

    private static func validatedIdentifier(
        _ value: String,
        field: String,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws -> String {
        let byteCount = value.utf8.count
        guard byteCount >= minimumBytes,
              byteCount <= maximumBytes,
              value.unicodeScalars.allSatisfy(Self.isIdentifierScalar) else {
            throw GaiCompanionEventTransportError.invalidField(field)
        }
        return value
    }

    private static func validatedMessage(_ value: String, field: String) throws -> String {
        let byteCount = value.utf8.count
        guard byteCount >= 1,
              byteCount <= 2_048,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy(Self.isDisplayScalar) else {
            throw GaiCompanionEventTransportError.invalidField(field)
        }
        return value
    }

    private static func isProviderIdentifier(_ value: String) -> Bool {
        guard value.utf8.count >= 1, value.utf8.count <= 64,
              let first = value.unicodeScalars.first,
              ("a"..."z").contains(Character(String(first))) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F:
                true
            default:
                false
            }
        }
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,
             0x2D, 0x2E, 0x3A, 0x40, 0x5F, 0x7E:
            true
        default:
            false
        }
    }

    private static func isDisplayScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F
    }
}

enum GaiCompanionEventTransportError: Error, Equatable {
    case invalidRoute
    case requestTooLarge
    case unknownField(String)
    case duplicateField(String)
    case missingField(String)
    case invalidField(String)
    case unsupportedVersion(String)
}
#endif
