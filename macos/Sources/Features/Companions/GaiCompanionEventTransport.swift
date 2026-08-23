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
    /// A final-message payload is useful for Teddy, but it is never allowed to
    /// poison the provider lifecycle. The authenticated Stop still settles the
    /// doudou when an optional response cannot be decoded; the manager then
    /// falls back to its bounded terminal capture.
    let discardedMalformedResponse: Bool

    init(
        url: URL,
        responseBody: Data? = nil,
        receivedAt: Date = Date()
    ) throws {
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
        let encodedResponse = fields["response"]
        let declaredResponseByteCount = try fields["response_bytes"].map {
            guard let count = Int($0),
                  count > 0,
                  count <= Self.maximumResponseByteCount,
                  String(count) == $0 else {
                throw GaiCompanionEventTransportError.invalidField("response_bytes")
            }
            return count
        }
        let responseText: String?
        if let responseBody,
           declaredResponseByteCount == responseBody.count {
            responseText = try? Self.decodedResponse(responseBody)
        } else if responseBody == nil,
                  declaredResponseByteCount == nil,
                  let encodedResponse {
            responseText = try? Self.decodedResponse(encodedResponse)
        } else {
            responseText = nil
        }
        let carriedResponse = encodedResponse != nil
            || declaredResponseByteCount != nil
            || responseBody != nil

        self.version = Self.currentVersion
        self.token = token
        self.discardedMalformedResponse = carriedResponse && responseText == nil
        self.event = GaiCompanionEvent(
            surfaceID: surfaceID,
            provider: GaiCompanionProvider(rawValue: rawProvider),
            eventID: eventID,
            turnID: turnID,
            kind: kind,
            timestamp: receivedAt,
            message: message,
            responseText: responseText)
    }

    private static let maximumURLByteCount = GaiCompanionEventSocketServer.maximumFrameByteCount
    static let maximumResponseByteCount = 65_536
    private static let allowedFieldNames: Set<String> = [
        "v", "surface", "token", "provider", "kind", "event", "turn", "message",
        "response", "response_bytes",
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

    private static func decodedResponse(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= ((maximumResponseByteCount + 2) / 3) * 4,
              value.unicodeScalars.allSatisfy(Self.isBase64URLScalar) else {
            throw GaiCompanionEventTransportError.invalidField("response")
        }

        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else {
            throw GaiCompanionEventTransportError.invalidField("response")
        }
        return try decodedResponse(data)
    }

    private static func decodedResponse(_ data: Data) throws -> String {
        guard !data.isEmpty,
              data.count <= maximumResponseByteCount,
              let decoded = String(data: data, encoding: .utf8) else {
            throw GaiCompanionEventTransportError.invalidField("response")
        }

        let response = decoded
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty,
              !response.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw GaiCompanionEventTransportError.invalidField("response")
        }
        return response
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

    private static func isBase64URLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F:
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
