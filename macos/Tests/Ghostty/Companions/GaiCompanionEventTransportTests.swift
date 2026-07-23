#if DEBUG
import Foundation
import Testing
@testable import Ghostty

struct GaiCompanionEventTransportTests {
    private let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func decodesACompleteVersionOneEvent() throws {
        let url = try #require(URL(string:
            "gaiterm-debug://agent-event?v=1" +
                "&surface=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" +
                "&token=0123456789abcdef0123456789abcdef" +
                "&provider=codex&kind=stop&event=event-42" +
                "&turn=turn-9&message=Turn%20complete"))

        let envelope = try GaiCompanionEventEnvelope(url: url, receivedAt: receivedAt)

        #expect(envelope.version == 1)
        #expect(envelope.token == "0123456789abcdef0123456789abcdef")
        #expect(envelope.event.surfaceID == UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(envelope.event.provider == .codex)
        #expect(envelope.event.kind == .stop)
        #expect(envelope.event.eventID == "event-42")
        #expect(envelope.event.turnID == "turn-9")
        #expect(envelope.event.timestamp == receivedAt)
        #expect(envelope.event.message == "Turn complete")
    }

    @Test func decodesRequiredFieldsWithoutOptionalPayload() throws {
        let envelope = try GaiCompanionEventEnvelope(
            url: validURL(),
            receivedAt: receivedAt)

        #expect(envelope.event.provider == .claude)
        #expect(envelope.event.kind == .started)
        #expect(envelope.event.turnID == nil)
        #expect(envelope.event.message == nil)
    }

    @Test func rejectsWrongRouteAndUnsupportedVersion() throws {
        let releaseURL = try #require(URL(string:
            validURL().absoluteString.replacingOccurrences(
                of: "gaiterm-debug",
                with: "gaiterm")))
        #expect(throws: GaiCompanionEventTransportError.invalidRoute) {
            try GaiCompanionEventEnvelope(url: releaseURL)
        }

        let versionTwo = replacingQueryItem(in: validURL(), named: "v", with: "2")
        #expect(throws: GaiCompanionEventTransportError.unsupportedVersion("2")) {
            try GaiCompanionEventEnvelope(url: versionTwo)
        }
    }

    @Test func rejectsMissingDuplicateAndUnknownFields() throws {
        let missingToken = removingQueryItem(from: validURL(), named: "token")
        #expect(throws: GaiCompanionEventTransportError.missingField("token")) {
            try GaiCompanionEventEnvelope(url: missingToken)
        }

        var duplicateComponents = try #require(URLComponents(
            url: validURL(),
            resolvingAgainstBaseURL: false))
        duplicateComponents.queryItems?.append(URLQueryItem(name: "event", value: "second"))
        let duplicateURL = try #require(duplicateComponents.url)
        #expect(throws: GaiCompanionEventTransportError.duplicateField("event")) {
            try GaiCompanionEventEnvelope(url: duplicateURL)
        }

        var unknownComponents = try #require(URLComponents(
            url: validURL(),
            resolvingAgainstBaseURL: false))
        unknownComponents.queryItems?.append(URLQueryItem(name: "debug", value: "1"))
        let unknownURL = try #require(unknownComponents.url)
        #expect(throws: GaiCompanionEventTransportError.unknownField("debug")) {
            try GaiCompanionEventEnvelope(url: unknownURL)
        }
    }

    @Test func rejectsMalformedIdentityAndSemanticFields() {
        let invalidCases: [(String, String, String)] = [
            ("surface", "not-a-uuid", "surface"),
            ("token", "too-short", "token"),
            ("provider", "Claude Code", "provider"),
            ("kind", "finished", "kind"),
            ("event", "contains whitespace", "event"),
            ("turn", "", "turn"),
            ("message", " leading", "message"),
        ]

        for (queryName, value, expectedField) in invalidCases {
            let url = replacingQueryItem(in: validURL(), named: queryName, with: value)
            #expect(throws: GaiCompanionEventTransportError.invalidField(expectedField)) {
                try GaiCompanionEventEnvelope(url: url)
            }
        }
    }

    @Test func rejectsControlCharactersAndOversizedPayloads() {
        let controlMessage = replacingQueryItem(
            in: validURL(),
            named: "message",
            with: "done\nnow")
        #expect(throws: GaiCompanionEventTransportError.invalidField("message")) {
            try GaiCompanionEventEnvelope(url: controlMessage)
        }

        let longEvent = replacingQueryItem(
            in: validURL(),
            named: "event",
            with: String(repeating: "a", count: 257))
        #expect(throws: GaiCompanionEventTransportError.invalidField("event")) {
            try GaiCompanionEventEnvelope(url: longEvent)
        }
    }

    private func validURL() -> URL {
        URL(string:
            "gaiterm-debug://agent-event?v=1" +
                "&surface=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" +
                "&token=0123456789abcdef0123456789abcdef" +
                "&provider=claude&kind=started&event=event-1")!
    }

    private func replacingQueryItem(in url: URL, named name: String, with value: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index] = URLQueryItem(name: name, value: value)
        } else {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.url!
    }

    private func removingQueryItem(from url: URL, named name: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = components.queryItems?.filter { $0.name != name }
        return components.url!
    }
}
#endif
